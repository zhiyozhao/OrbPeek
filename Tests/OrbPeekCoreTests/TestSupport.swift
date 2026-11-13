import AppKit
import Foundation
@testable import OrbPeekCore

final class FakeClock {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_000)) { self.now = now }
    func advance(_ interval: TimeInterval) { now += interval }
}

final class FakeWindow: WindowHandle {
    var storedFrame: CGRect?
    var readDelay: TimeInterval = 0
    var clock: FakeClock?
    var positionWrites: [CGPoint] = []
    var minimized = false
    var appHidden = false
    var mouseDown = false
    var pid: pid_t? = 42

    init(frame: CGRect) { self.storedFrame = frame }

    var frame: CGRect? {
        clock?.advance(readDelay)
        return storedFrame
    }
    var position: CGPoint? {
        get { storedFrame?.origin }
        set {
            guard let newValue else { return }
            storedFrame?.origin = newValue
            positionWrites.append(newValue)
        }
    }
    var isMinimized: Bool { minimized }
    var isAppHidden: Bool { appHidden }
    func unminimize() { minimized = false }
    func raise() {}
    func activate() {}
    func isSameWindow(as other: any WindowHandle) -> Bool { self === other }
}

@MainActor
final class FakeCapturer: SliceCapturing {
    var onCapture: (() -> Void)?
    var captureCount = 0
    func windowID(for pid: pid_t, matching frame: CGRect) -> CGWindowID? { 7 }
    func windowExists(_ id: CGWindowID) -> Bool { true }
    func cachedSlice(for windowID: CGWindowID, edge: DockEdge, size: CGSize, thickness: CGFloat) -> NSImage? { nil }
    func captureWindow(frame: CGRect, displayID: CGDirectDisplayID?, windowID: CGWindowID?) async -> CGImage? {
        captureCount += 1
        onCapture?()
        return nil
    }
    func slice(from image: CGImage, edge: DockEdge, windowSize: CGSize, thickness: CGFloat) -> NSImage? { nil }
}

@MainActor
final class FakeStrip: SnapshotStripHandling {
    var frame: NSRect = .zero
    var thickness: CGFloat = 0
    var alphaValue: CGFloat = 1
    var level: NSWindow.Level = .floating
    var visible = false
    func show(image: NSImage?, frame: NSRect, edge: DockEdge) {
        self.frame = frame
        thickness = edge.slideAxis == .vertical ? frame.height : frame.width
        visible = true
    }
    func updateFrame(_ frame: NSRect, edge: DockEdge) { self.frame = frame }
    func hide() { visible = false }
}

final class LayoutBox {
    var layout: ScreenLayout
    init(_ layout: ScreenLayout) { self.layout = layout }
}

@MainActor
final class FakeDelegate: WindowDockDelegate {
    var config = DockConfiguration()
    let layoutBox: LayoutBox
    var geometry: WindowGeometry { WindowGeometry(layoutProvider: { self.layoutBox.layout }) }
    let fakeCapturer = FakeCapturer()
    var capturer: any SliceCapturing { fakeCapturer }
    let strip = FakeStrip()
    var frontmost = true
    var removed: [ManagedWindow] = []

    init(layout: ScreenLayout) { self.layoutBox = LayoutBox(layout) }
    func makeStrip() -> any SnapshotStripHandling { strip }
    func nameForWindow(_ window: any WindowHandle) -> String { "Fake" }
    func activate(window: any WindowHandle) {}
    func isFrontmost(_ window: any WindowHandle) -> Bool { frontmost }
    func removeManaged(_ managed: ManagedWindow) { removed.append(managed) }
}

struct ManagedFixture {
    let managed: ManagedWindow
    let window: FakeWindow
    let delegate: FakeDelegate
    let clock: FakeClock
}

@MainActor
func makeIdleFixture(layout: ScreenLayout, frame: CGRect = CGRect(x: 300, y: 200, width: 700, height: 500),
                     edge: DockEdge = .down) -> ManagedFixture {
    let clock = FakeClock()
    let window = FakeWindow(frame: frame)
    window.clock = clock
    let delegate = FakeDelegate(layout: layout)
    let managed = ManagedWindow(window: window, edge: edge, delegate: delegate, clock: { clock.now })
    managed.isLeftMousePressed = { window.mouseDown }
    return ManagedFixture(managed: managed, window: window, delegate: delegate, clock: clock)
}

@MainActor
func makeDockedFixture(layout: ScreenLayout, frame: CGRect = CGRect(x: 300, y: 200, width: 700, height: 500),
                       edge: DockEdge = .down) async -> ManagedFixture {
    let fixture = makeIdleFixture(layout: layout, frame: frame, edge: edge)
    fixture.managed.dock()
    await drainTasks()
    return fixture
}

func drainTasks() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
func tick(_ fixture: ManagedFixture, settling: Bool = false, frontmost: Bool = true) {
    let mouse = fixture.window.storedFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
    fixture.managed.evaluate(mouseQ: mouse, mouseVelocity: .zero, frontmost: frontmost,
                             blockedByPeeked: false, blockedBySmaller: false,
                             settling: settling, now: fixture.clock.now)
}

let testPrimary = ScreenInfo(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
)
let testSecondary = ScreenInfo(
    id: 2,
    frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
)
let testLayout = ScreenLayout(screens: [testPrimary, testSecondary])
