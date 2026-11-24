import Foundation
import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("display rules v2")
@MainActor
struct DisplayRulesV2Tests {
    @MainActor
    final class Harness {
        let clock = FakeClock()
        let delegate: FakeDelegate
        let session: DockSession
        let window: FakeWindow
        let managed: ManagedWindow
        static let a = ScreenInfo(id: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), displayUUID: "U2790B")
        static let b = ScreenInfo(id: 3, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1055), displayUUID: "Mi")
        static let internalScreen = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
                                               visibleFrame: CGRect(x: 0, y: 0, width: 1352, height: 843), displayUUID: "built-in")
        init(single: Bool = false, edge: DockEdge = .down) async {
            delegate = FakeDelegate(layout: ScreenLayout(screens: single ? [Self.a] : [Self.a, Self.b]))
            let layoutSource = delegate.layoutBox
            let timer = clock
            delegate.layoutCache = DisplayLayoutCache(load: { layoutSource.read() }, clock: { timer.now })
            session = DockSession(delegate: delegate, clock: { timer.now })
            delegate.onOfflineRelease = session.deferPending
            window = FakeWindow(frame: CGRect(x: 851, y: 412, width: 308, height: 668))
            let target = window
            managed = session.add(window: window, edge: edge) { $0.isLeftMousePressed = { target.mouseDown } }
            await drainTasks()
        }
        func change(_ screens: [ScreenInfo]) {
            delegate.layoutBox.layout = ScreenLayout(screens: screens)
            session.screenChanged()
        }
        func poll(_ seconds: Double = 0) {
            clock.advance(seconds)
            session.poll(mouseQ: CGPoint(x: -99999, y: -99999))
            #expect(session.unreachableWindows().isEmpty)
        }
        func release() {
            change([Self.internalScreen])
            poll()
            poll(10.1)
            #expect(session.windows.isEmpty)
            #expect(session.released.count == 1)
        }
    }

    @Test("stable baseline survives layout notifications 31–43ms before lock", arguments: [0.031, 0.043], [false, true])
    func stableBaseline(delay: Double, peeked: Bool) async {
        let h = await Harness()
        if peeked { h.managed.peek() }
        let original = h.window.frame
        let baseline = h.session.stableLayout
        h.session.reconfigurationBegan()
        h.change([ScreenInfo(id: 5, frame: Harness.a.frame, visibleFrame: Harness.a.visibleFrame, displayUUID: "transient")])
        h.clock.advance(delay)
        h.session.lock()
        #expect(h.session.suspensionBaseline == baseline)
        let writes = h.window.positionWrites.count
        for _ in 0..<108 { h.change([Harness.internalScreen]); h.poll(1) }
        h.window.storedFrame?.origin.x = 0
        h.change([Harness.a, Harness.b])
        h.session.reconfigurationEnded()
        h.session.unlock()
        // The original stable layout is already back: reconciliation is now
        // synchronous, before the first post-unlock interaction poll.
        #expect(h.session.canWriteAutomatically)
        h.poll()
        #expect(h.session.windows.count == 1)
        #expect(h.window.frame == original)
        #expect(h.window.positionWrites.count == writes + 1)
        #expect(h.managed.phase == (peeked ? .peeked : .docked))
        #expect(h.delegate.activationCount == (peeked ? 1 : 0))
    }

    @Test("UUID identity survives ID reassignment and ID reuse never impersonates a screen")
    func identity() async {
        let h = await Harness()
        let parked = h.window.frame
        let changed = ScreenInfo(id: 24, frame: Harness.a.frame, visibleFrame: Harness.a.visibleFrame, displayUUID: "U2790B")
        h.change([changed, Harness.b])
        h.poll(3.1)
        #expect(h.session.windows.count == 1)
        #expect(h.managed.ownedScreen(in: h.delegate.geometry)?.id == 24)
        #expect(h.window.frame == parked)
        h.change([ScreenInfo(id: 24, frame: Harness.a.frame, visibleFrame: Harness.a.visibleFrame, displayUUID: "different-hardware"), Harness.b])
        h.poll(9.9)
        #expect(h.session.windows.count == 1)
        h.poll(0.2)
        #expect(h.session.windows.isEmpty)
    }

    @Test("duplicate UUIDs are ambiguous and identical sizes do not establish identity")
    func ambiguousIdentity() async {
        let h = await Harness()
        h.change([Harness.a, ScreenInfo(id: 30, frame: Harness.b.frame, visibleFrame: Harness.b.visibleFrame, displayUUID: "U2790B")])
        h.poll(10.1)
        #expect(h.session.windows.isEmpty)
    }

    @Test("menu and Dock margins, resolution, arrangement and primary changes keep outer-edge docks", arguments: [0, 1, 2, 3, 4])
    func workspaceChanges(kind: Int) async {
        let h = await Harness()
        let offset = h.managed.perp
        let a: ScreenInfo
        let b: ScreenInfo
        switch kind {
        case 0: // Real log: menu bar settles from full 1080 to 1055.
            a = ScreenInfo(id: 2, frame: Harness.a.frame, visibleFrame: Harness.a.frame, displayUUID: "U2790B")
            b = Harness.b
        case 1: // Dock moved to the side.
            a = ScreenInfo(id: 2, frame: Harness.a.frame, visibleFrame: CGRect(x: 60, y: 0, width: 1860, height: 1055), displayUUID: "U2790B")
            b = Harness.b
        case 2: // A logical resolution/scale change.
            a = ScreenInfo(id: 2, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                           visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 975), displayUUID: "U2790B")
            b = ScreenInfo(id: 3, frame: Harness.b.frame.offsetBy(dx: -320, dy: 0), visibleFrame: Harness.b.visibleFrame.offsetBy(dx: -320, dy: 0), displayUUID: "Mi")
        case 3:
            a = ScreenInfo(id: 2, frame: Harness.a.frame.offsetBy(dx: -1920, dy: 0), visibleFrame: Harness.a.visibleFrame.offsetBy(dx: -1920, dy: 0), displayUUID: "U2790B")
            b = ScreenInfo(id: 3, frame: Harness.b.frame.offsetBy(dx: -1920, dy: 0), visibleFrame: Harness.b.visibleFrame.offsetBy(dx: -1920, dy: 0), displayUUID: "Mi")
        default:
            a = Harness.a; b = Harness.b // Pixel density/refresh-only notification.
        }
        h.change(kind == 3 ? [b, a] : [a, b])
        h.poll(3.1)
        #expect(h.session.windows.count == 1)
        #expect(h.managed.perp == offset)
        #expect(h.managed.phase == .docked)
        if kind == 0 {
            h.change([Harness.a, Harness.b]); h.poll(3.1)
            #expect(h.session.windows.count == 1)
        }
    }

    @Test("adjacent screen plug and unplug retain all four edges and relocate hidden parking", arguments: [DockEdge.left, .right, .up, .down], [false, true])
    func adjacentDisplay(edge: DockEdge, peeked: Bool) async {
        let h = await Harness(single: true, edge: edge)
        #expect(h.window.frame?.minX == 1919)
        if peeked { h.managed.peek() }
        let perp = h.managed.perp
        let activations = h.delegate.activationCount
        h.change([Harness.a, Harness.b])
        h.poll(3.1)
        #expect(h.session.windows.count == 1)
        #expect(h.session.released.isEmpty)
        #expect(h.managed.phase == (peeked ? .peeked : .docked))
        #expect(h.managed.perp == perp)
        let target = peeked
            ? h.delegate.geometry.peekPosition(for: edge, size: h.window.frame!.size, perp: perp, screen: Harness.a)
            : h.delegate.geometry.hiddenPosition(for: edge, size: h.window.frame!.size, perp: perp, screen: Harness.a)
        #expect(h.window.frame?.origin == target)
        if !peeked {
            #expect(h.window.frame?.minX == -307)
            #expect(h.managed.hasReachableStrip(in: h.delegate.geometry))
            let strip = h.delegate.geometry.toAppKit(h.delegate.geometry.sliverRect(edge: edge, size: h.window.frame!.size,
                perp: perp, screen: Harness.a, thickness: h.delegate.config.sliverPx))
            #expect(h.delegate.strips.last?.frame == strip)
        }
        h.change([Harness.a]); h.poll(3.1)
        #expect(h.session.windows.count == 1)
        #expect(h.session.released.isEmpty)
        #expect(h.managed.phase == (peeked ? .peeked : .docked))
        #expect(h.delegate.activationCount == activations)
        if !peeked { #expect(h.window.frame?.minX == 1919) }
    }

    @Test("a middle display and a vertically adjacent display keep every docked edge", arguments: [DockEdge.left, .right, .up, .down])
    func middleAndStackedScreens(edge: DockEdge) async {
        let clock = FakeClock()
        let third = ScreenInfo(id: 4, frame: CGRect(x: 3840, y: 0, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 3840, y: 0, width: 1920, height: 1055), displayUUID: "third")
        let delegate = FakeDelegate(layout: ScreenLayout(screens: [Harness.a, Harness.b, third]))
        let session = DockSession(delegate: delegate, clock: { clock.now })
        let window = FakeWindow(frame: CGRect(x: 2200, y: 200, width: 500, height: 400))
        let managed = session.add(window: window, edge: edge) { $0.isLeftMousePressed = { false } }
        await drainTasks()
        #expect(window.frame?.minX == 5759) // Middle-screen parking goes beyond the whole desktop.
        #expect(managed.hasReachableStrip(in: delegate.geometry))
        delegate.layoutBox.layout = ScreenLayout(screens: [Harness.a, Harness.b])
        session.screenChanged(); clock.advance(3.1); session.poll(mouseQ: CGPoint(x: -9999, y: -9999))
        #expect(window.frame?.minX == 3839)
        #expect(session.windows.count == 1 && session.released.isEmpty)
        managed.peek()
        #expect(window.frame?.origin == delegate.geometry.peekPosition(for: edge, size: window.frame!.size,
                                                                       perp: managed.perp, screen: Harness.b))
        let h = await Harness(single: true, edge: edge)
        let below = ScreenInfo(id: 8, frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1055), displayUUID: "below")
        h.change([Harness.a, below]); h.poll(3.1)
        #expect(h.session.windows.count == 1 && h.session.released.isEmpty)
        #expect(h.managed.phase == .docked && h.managed.edge == edge)
        #expect(h.managed.hasReachableStrip(in: h.delegate.geometry))
        h.change([Harness.a]); h.poll(3.1)
        #expect(h.session.windows.count == 1 && h.session.released.isEmpty)
    }

    @Test("ten-second grace resets after last related event; slow screens never redock", arguments: [9.9, 10.1, 66.847])
    func slowWake(delay: Double) async {
        let h = await Harness()
        h.session.sleep()
        h.change([Harness.internalScreen])
        h.session.wake()
        if delay < 10 {
            h.poll(delay)
            #expect(h.session.windows.count == 1)
        } else {
            h.poll(10.01)
            #expect(h.session.windows.isEmpty)
            h.clock.advance(delay - 10.01)
        }
        h.change([Harness.a, Harness.b])
        h.poll(3.1)
        #expect(h.session.windows.count == (delay < 10 ? 1 : 0))
        if delay >= 10 {
            h.poll(3600)
            #expect(h.session.windows.isEmpty)
        }
    }

    @Test("nested sleep, lock, inactive session and screen saver independently freeze every entry point")
    func suspension() async {
        let h = await Harness()
        h.managed.peek()
        h.session.lock(); h.session.sleep(); h.session.setSessionActive(false)
        let frame = h.window.frame
        let writes = h.window.positionWrites.count
        let activations = h.delegate.activationCount
        h.managed.peek(); h.managed.dock(); h.managed.redock(to: .up)
        h.managed.beginGesture(at: .zero); h.managed.endGesture(); h.managed.restore()
        h.session.rescueAllWindows()
        h.session.wake(); h.poll(20)
        h.session.unlock(); h.poll(20)
        #expect(h.window.frame == frame)
        #expect(h.window.positionWrites.count == writes)
        #expect(h.delegate.activationCount == activations)
        h.session.setSessionActive(true); h.session.setScreenSaverActive(true); h.poll(20)
        #expect(h.window.positionWrites.count == writes)
        h.session.setScreenSaverActive(false); h.poll(3.1)
        #expect(h.session.windows.isEmpty) // queued manual rescue, not an automatic release
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
    }

    @Test("strict fingerprints rescue repeated delayed system restores but ignore user placement elsewhere")
    func fingerprints() async {
        let h = await Harness()
        let hidden = h.window.frame!
        h.release()
        h.window.storedFrame = hidden.offsetBy(dx: -100, dy: -50)
        let userPosition = h.window.frame
        h.poll(3600)
        #expect(h.window.frame == userPosition)
        h.change([Harness.a, Harness.b]); h.poll(3.1)
        #expect(h.window.frame == userPosition)
        for delay in [1.1, 3600, 7200] {
            h.window.storedFrame = hidden.offsetBy(dx: 1, dy: -1)
            h.poll(delay)
            #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
            #expect(h.session.windows.isEmpty)
            #expect(h.session.released.count == 1)
        }
        #expect(h.delegate.activationCount == 0)
        #expect(h.window.raiseCount == 0)
        // An exact old coordinate which is now visible is also untouched.
        h.change([ScreenInfo(id: 2, frame: Harness.a.frame.offsetBy(dx: -1920, dy: 0),
                            visibleFrame: Harness.a.visibleFrame.offsetBy(dx: -1920, dy: 0), displayUUID: "U2790B"), Harness.b])
        h.window.storedFrame = hidden
        h.poll(3.1)
        #expect(h.window.frame == hidden)
    }

    @Test("AX, drag, minimize and app hide defer exact-fingerprint rescue and failed writes retry")
    func deferredRescue() async {
        let h = await Harness()
        let hidden = h.window.frame!
        h.release()
        h.window.storedFrame = hidden
        let writes = h.window.positionWrites.count
        h.window.mouseDown = true; h.poll(2)
        h.window.mouseDown = false; h.window.minimized = true; h.poll(2)
        h.window.minimized = false; h.window.appHidden = true; h.poll(2)
        h.window.appHidden = false; h.window.storedFrame = nil; h.poll(2)
        #expect(h.window.positionWrites.count == writes)
        h.window.storedFrame = hidden
        h.window.rejectWrites = true
        h.clock.advance(2); h.session.poll()
        #expect(h.session.released.count == 1)
        h.window.rejectWrites = false; h.poll(2)
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
    }

    @Test("manual rescue finds managed and listed windows, including user positions outside fingerprints")
    func rescueAll() async {
        let h = await Harness()
        h.release()
        h.window.storedFrame = CGRect(x: -10000, y: -9000, width: 3000, height: 2000)
        let other = FakeWindow(frame: CGRect(x: 300, y: 150, width: 500, height: 400))
        _ = h.session.add(window: other, edge: .down) { $0.isLeftMousePressed = { false } }
        await drainTasks()
        h.session.rescueAllWindows()
        h.poll()
        #expect(h.session.windows.isEmpty)
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
        #expect(h.delegate.geometry.visibleFraction(of: other.frame!) == 1)
        #expect(h.delegate.strips.allSatisfy { !$0.isVisible })
    }

    @Test("zero/invalid geometry never decides or consumes the stable baseline")
    func invalidDesktop() async {
        let h = await Harness()
        let baseline = h.session.stableLayout
        let writes = h.window.positionWrites.count
        h.change([]); h.poll(120)
        h.change([ScreenInfo(id: 1, frame: .zero, visibleFrame: .zero)]); h.poll(120)
        #expect(h.window.positionWrites.count == writes)
        #expect(h.session.stableLayout == baseline)
        #expect(!h.session.recoveryReady)
        h.change([Harness.a, Harness.b]); h.poll(3.1)
        #expect(h.session.windows.count == 1)
    }

    @Test("grab-in-flight cannot hide after pause and resumes without activating", arguments: [false, true])
    func captureRace(locked: Bool) async {
        let h = await Harness()
        h.managed.peek()
        h.delegate.fakeCapturer.onCapture = {
            if locked { h.session.lock() } else { h.change([Harness.internalScreen]) }
        }
        let writes = h.window.positionWrites.count
        h.managed.dock()
        await drainTasks()
        #expect(h.window.positionWrites.count == writes)
        h.delegate.fakeCapturer.onCapture = nil
        if locked { h.session.unlock() } else { h.change([Harness.a, Harness.b]) }
        h.poll(3.1)
        await drainTasks()
        #expect(h.managed.phase == .docked)
        #expect(h.session.unreachableWindows().isEmpty)
        #expect(h.delegate.activationCount == 1)
    }

    @Test("mirror receivers add no desktop; extended-to-mirror releases only lost desktop")
    func mirror() async {
        let h = await Harness()
        let receiver = ScreenInfo(id: 99, frame: Harness.a.frame, visibleFrame: Harness.a.visibleFrame,
                                  displayUUID: "receiver", mirrorSourceID: 2)
        h.change([Harness.a, Harness.b, receiver]); h.poll(3.1)
        #expect(h.session.windows.count == 1)
        h.change([Harness.a, ScreenInfo(id: 3, frame: Harness.a.frame, visibleFrame: Harness.a.visibleFrame,
                                       displayUUID: "Mi", mirrorSourceID: 2)])
        h.poll(3.1)
        #expect(h.session.windows.count == 1)
        // Restoring extension relocates parking while retaining the source;
        // adjacentDisplay independently covers that behavior on every edge.
        let extended = await Harness()
        let lost = FakeWindow(frame: CGRect(x: 2100, y: 300, width: 500, height: 400))
        let dock = extended.session.add(window: lost, edge: .down) { $0.isLeftMousePressed = { false } }
        await drainTasks()
        extended.change([Harness.a]); extended.poll(10.1)
        #expect(!extended.session.windows.contains { $0 === dock })
        #expect(extended.session.windows.contains { $0 === extended.managed })
    }

    @Test("projection/AirPlay/Sidecar endpoints obey the same return deadline", arguments: ["projector", "AirPlay", "Sidecar"])
    func virtualDisplays(endpoint: String) async {
        let h = await Harness()
        let virtual = ScreenInfo(id: 10, frame: Harness.b.frame, visibleFrame: Harness.b.visibleFrame, displayUUID: endpoint)
        h.change([Harness.a, virtual]); h.poll(3.1)
        let window = FakeWindow(frame: CGRect(x: 2100, y: 300, width: 500, height: 400))
        let dock = h.session.add(window: window, edge: .down) { $0.isLeftMousePressed = { false } }
        await drainTasks()
        h.change([Harness.a]); h.poll(1)
        h.change([Harness.a, virtual]); h.poll(3.1)
        #expect(h.session.windows.contains { $0 === dock })
        h.change([Harness.a]); h.poll(10.1)
        h.change([Harness.a, virtual]); h.poll(3.1)
        #expect(!h.session.windows.contains { $0 === dock })
    }

    @Test("visible union counts overlap once and excludes desktop holes")
    func visibleUnion() {
        let a = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let duplicate = ScreenInfo(id: 2, frame: a.frame, visibleFrame: a.visibleFrame)
        let g = WindowGeometry(layout: ScreenLayout(screens: [a, duplicate]))
        #expect(abs(g.visibleFraction(of: CGRect(x: -92, y: 0, width: 100, height: 100)) - 0.08) < 0.001)
        let distant = ScreenInfo(id: 3, frame: a.frame.offsetBy(dx: 200, dy: 0), visibleFrame: a.visibleFrame.offsetBy(dx: 200, dy: 0))
        let holes = WindowGeometry(layout: ScreenLayout(screens: [a, distant]))
        #expect(holes.visibleFraction(of: CGRect(x: 100, y: 0, width: 100, height: 100)) == 0)
    }

    @Test("last related event restarts the full missing-screen deadline")
    func deadlineRestarts() async {
        let h = await Harness()
        let writes = h.window.positionWrites.count
        h.change([Harness.internalScreen]); h.poll(9)
        h.session.screenChanged(); h.poll(9)
        #expect(h.session.windows.count == 1)
        #expect(h.window.positionWrites.count == writes)
        h.poll(1.1)
        #expect(h.session.windows.isEmpty)
    }

    @Test("a managed window with failed release retains an online strip until AX succeeds")
    func failedReleaseKeepsOwnership() async {
        let h = await Harness()
        h.window.rejectWrites = true
        h.change([Harness.internalScreen]); h.poll(10.1)
        #expect(h.session.windows.count == 1)
        #expect(h.managed.hasReachableStrip(in: h.delegate.geometry))
        #expect(h.session.released.isEmpty)
        h.window.rejectWrites = false; h.poll(2)
        #expect(h.session.windows.isEmpty)
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
    }

    @Test("closed handles are removed; successful rescue alone keeps fingerprints; explicit docking takes ownership")
    func recordLifetime() async {
        let h = await Harness()
        let hidden = h.window.frame!
        h.release()
        h.window.storedFrame = hidden; h.poll(2)
        #expect(h.session.released.count == 1)
        _ = h.session.add(window: h.window, edge: .down) { $0.isLeftMousePressed = { false } }
        await drainTasks()
        #expect(h.session.released.isEmpty)
        h.session.rescueAllWindows()
        #expect(h.session.released.count == 1)
        h.delegate.fakeCapturer.windowIsInWindowList = false; h.poll(2)
        #expect(h.session.released.isEmpty)
    }

    @Test("online-strip invariant repairs a panel disappearing without a topology event")
    func missingStrip() async {
        let h = await Harness()
        h.delegate.strip.hide()
        h.poll()
        #expect(h.managed.hasReachableStrip(in: h.delegate.geometry))
    }

    @Test("AX reads that observe suspension cannot activate or write afterwards")
    func suspensionDuringRead() async {
        let h = await Harness()
        let writes = h.window.positionWrites.count
        h.window.onRead = { h.window.onRead = nil; h.session.lock() }
        h.managed.peek()
        #expect(h.window.positionWrites.count == writes)
        #expect(h.window.raiseCount == 0)
        #expect(h.delegate.activationCount == 0)
    }

    @Test("failed menu cancellation retains ownership and an online strip until retry succeeds")
    func failedMenuCancel() async {
        let h = await Harness()
        h.window.rejectWrites = true
        h.managed.terminate(exit: .restore)
        #expect(h.delegate.removed.isEmpty)
        h.poll(1)
        h.window.rejectWrites = false
        h.poll(1)
        #expect(h.delegate.removed.count == 1)
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) >= 0.99)
        #expect(h.session.released.isEmpty)
    }

    @Test("rescue revalidates the fingerprint when the window moves between AX reads")
    func rescueReadRace() async {
        let h = await Harness()
        let parked = h.window.frame!
        h.release()
        h.change([Harness.a, Harness.b]); h.poll(3.1)
        h.window.storedFrame = parked
        let userFrame = CGRect(x: -1200, y: 200, width: 308, height: 668)
        var reads = 0
        h.window.onRead = {
            reads += 1
            if reads == 3 { h.window.storedFrame = userFrame }
        }
        let writes = h.window.positionWrites.count
        h.poll(1.1)
        h.window.onRead = nil
        #expect(h.window.positionWrites.count == writes)
        #expect(h.window.frame == userFrame)
    }

    @Test("fingerprint rescue shrinks oversized windows before positioning on a smaller desktop")
    func resizedRescue() async {
        let h = await Harness()
        let parked = h.window.frame!
        h.release()
        let small = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 400),
                               visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 400), displayUUID: "built-in")
        h.change([small]); h.poll(3.1)
        h.window.storedFrame = parked
        h.poll(1.1)
        #expect(h.window.frame?.height == 400)
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
    }

    @Test("the waiting strip fits a desktop smaller than the managed window even when AX rejects placement")
    func oversizedWaitingStrip() async {
        let h = await Harness()
        h.window.rejectWrites = true
        let small = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 240, height: 400),
                               visibleFrame: CGRect(x: 0, y: 0, width: 240, height: 400), displayUUID: "built-in")
        h.change([small]); h.poll(); h.poll(10.1)
        #expect(h.session.windows.count == 1)
        #expect(h.managed.hasReachableStrip(in: h.delegate.geometry))
    }

    @Test("quit rescues listed parking positions or retains an unclean recovery record on failure", arguments: [false, true])
    func releasedQuit(rejectWrites: Bool) async throws {
        let h = await Harness()
        let parked = h.window.frame!
        h.release()
        h.window.storedFrame = parked
        h.window.rejectWrites = rejectWrites
        let exited = h.session.quit()
        if rejectWrites {
            let record = try #require(exited.first?.persistenceRecord(cleanExit: true, exitedAt: h.clock.now))
            #expect(!record.isCleanExit)
        } else {
            #expect(exited.isEmpty)
            #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
        }
        #expect(h.session.released.isEmpty)
    }

    @Test("morning incident waits ten seconds, releases once, never redocks")
    func morningTimeline() async {
        let server = await FakeWindowServer()
        let originals = server.windows
        let hidden = originals.map { $0.window.frame! }
        server.session.lock()
        server.removeExternalDisplays()
        server.clock.advance(80)
        server.openBuiltInDisplay()
        server.session.unlock()
        let writes = originals.map { ($0.window as! FakeWindow).positionWrites.count }
        for _ in 0..<90 { server.clock.advance(0.1); server.session.poll() }
        #expect(server.windows.count == 2)
        #expect(originals.map { ($0.window as! FakeWindow).positionWrites.count } == writes)
        server.clock.advance(2)
        server.session.poll()
        #expect(server.windows.isEmpty)
        server.clock.advance(67)
        server.delegate.layoutBox.layout = server.externalLayout
        server.session.screenChanged()
        for (managed, frame) in zip(originals, hidden) { (managed.window as! FakeWindow).storedFrame = frame }
        server.clock.advance(11)
        server.session.poll()
        await drainTasks()
        #expect(server.windows.isEmpty)
        for managed in originals {
            #expect(server.externalLayout.screens.contains {
                server.delegate.geometry.quartzVisibleFrame(of: $0).contains(managed.window.frame!)
            })
        }
    }
}
