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
    var sizeWrites: [CGSize] = []
    private var lastKnownSize: CGSize
    var minimized = false
    var appHidden = false
    var mouseDown = false
    var raiseCount = 0
    var activateCount = 0
    var pid: pid_t? = 42
    var windowID: CGWindowID?
    var title: String? = "Fake"
    var bundleIdentifier: String? = "fake.app"

    init(frame: CGRect) {
        self.storedFrame = frame
        self.lastKnownSize = frame.size
    }

    var frame: CGRect? {
        clock?.advance(readDelay)
        return storedFrame
    }
    var position: CGPoint? {
        get { storedFrame?.origin }
        set {
            guard let newValue else { return }
            if storedFrame == nil { storedFrame = CGRect(origin: newValue, size: lastKnownSize) }
            storedFrame?.origin = newValue
            positionWrites.append(newValue)
        }
    }
    var isMinimized: Bool { minimized }
    var isAppHidden: Bool { appHidden }
    func unminimize() { minimized = false }
    func raise() { raiseCount += 1 }
    func activate() { activateCount += 1 }
    func resize(to size: CGSize) {
        lastKnownSize = size
        if storedFrame == nil { storedFrame = CGRect(origin: .zero, size: size) }
        storedFrame?.size = size
        sizeWrites.append(size)
    }
    func isSameWindow(as other: any WindowHandle) -> Bool { self === other }
}

@MainActor
final class FakeCapturer: SliceCapturing {
    var contentInvalidations: [String] = []
    func invalidateContent(reason: String) { contentInvalidations.append(reason) }
    var onCapture: (() -> Void)?
    var captureCount = 0
    var windowIsInWindowList = true
    func windowID(for pid: pid_t, matching frame: CGRect) -> CGWindowID? { 7 }
    func windowExists(_ id: CGWindowID) -> Bool { windowIsInWindowList }
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
    var isVisible: Bool { visible }
    var showCount = 0
    func show(image: NSImage?, frame: NSRect, edge: DockEdge) {
        showCount += 1
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
    var offlinePolicy: DockSessionOptions.OfflinePolicy = .migrate
    var strips: [FakeStrip] = []
    var strip: FakeStrip { strips[0] }
    var frontmost = true
    var removed: [ManagedWindow] = []
    var stateChangeCount = 0
    var activationCount = 0
    var onOfflineRelease: ((ManagedWindow) -> Void)?

    init(layout: ScreenLayout) { self.layoutBox = LayoutBox(layout) }
    func makeStrip() -> any SnapshotStripHandling {
        let strip = FakeStrip()
        strips.append(strip)
        return strip
    }
    func nameForWindow(_ window: any WindowHandle) -> String { "Fake" }
    func activate(window: any WindowHandle) { activationCount += 1 }
    func isFrontmost(_ window: any WindowHandle) -> Bool { frontmost }
    func dockStateDidChange() { stateChangeCount += 1 }
    func offlineWindowReleased(_ managed: ManagedWindow) { onOfflineRelease?(managed) }
    func removeManaged(_ managed: ManagedWindow) {
        removed.append(managed)
        stateChangeCount += 1
    }
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
    managed.log = { _ in }
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
