import AppKit
import Testing
@testable import OrbPeekCore

// Deliberately uses only APIs already present on main. It proves the original
// defect is a behavioral failure, not merely a missing-DockSession compile error.
private final class LegacyWindow: WindowHandle {
    var frame: CGRect?
    var position: CGPoint? {
        get { frame?.origin }
        set { if let newValue { frame?.origin = newValue } }
    }
    var isMinimized = false
    var isAppHidden = false
    var pid: pid_t? = 42
    var title: String? = "Legacy"
    var bundleIdentifier: String? = "legacy.app"
    init(frame: CGRect) { self.frame = frame }
    func unminimize() {}
    func raise() {}
    func activate() {}
    func resize(to size: CGSize) { frame?.size = size }
    func isSameWindow(as other: any WindowHandle) -> Bool { self === other }
}

@MainActor
private final class LegacyCapturer: SliceCapturing {
    func windowID(for pid: pid_t, matching frame: CGRect) -> CGWindowID? { nil }
    func windowExists(_ id: CGWindowID) -> Bool { false }
    func cachedSlice(for windowID: CGWindowID, edge: DockEdge, size: CGSize, thickness: CGFloat) -> NSImage? { nil }
    func captureWindow(frame: CGRect, displayID: CGDirectDisplayID?, windowID: CGWindowID?) async -> CGImage? { nil }
    func slice(from image: CGImage, edge: DockEdge, windowSize: CGSize, thickness: CGFloat) -> NSImage? { nil }
}

@MainActor
private final class LegacyStrip: SnapshotStripHandling {
    var frame: NSRect = .zero
    var thickness: CGFloat = 0
    var alphaValue: CGFloat = 1
    var level: NSWindow.Level = .floating
    var isVisible = true
    func show(image: NSImage?, frame: NSRect, edge: DockEdge) { self.frame = frame; isVisible = true }
    func updateFrame(_ frame: NSRect, edge: DockEdge) { self.frame = frame }
    func hide() { isVisible = false }
}

private final class LegacyLayout {
    var layout: ScreenLayout
    init(_ layout: ScreenLayout) { self.layout = layout }
}

@MainActor
private final class LegacyDelegate: WindowDockDelegate {
    var config = DockConfiguration()
    let layout: LegacyLayout
    var geometry: WindowGeometry { WindowGeometry(layoutProvider: { self.layout.layout }) }
    var capturer: any SliceCapturing { LegacyCapturer() }
    var removed: [ManagedWindow] = []
    init(layout: ScreenLayout) { self.layout = LegacyLayout(layout) }
    func makeStrip() -> any SnapshotStripHandling { LegacyStrip() }
    func nameForWindow(_ window: any WindowHandle) -> String { "Legacy" }
    func activate(window: any WindowHandle) {}
    func isFrontmost(_ window: any WindowHandle) -> Bool { true }
    func dockStateDidChange() {}
    func removeManaged(_ managed: ManagedWindow) { removed.append(managed) }
}

@Suite("main-compatible incident probe")
@MainActor
struct LegacyIncidentScenarioTests {
    @Test("off-screen strip is a real failure on main")
    func twoWindowsAfterDisplayLoss() async {
        let external = ScreenLayout(screens: [testPrimary, testSecondary])
        let delegate = LegacyDelegate(layout: external)
        let first = LegacyWindow(frame: CGRect(x: 633, y: 566, width: 722, height: 496))
        let second = LegacyWindow(frame: CGRect(x: 1500, y: 326, width: 308, height: 668))
        let managed = [
            ManagedWindow(window: first, edge: .down, delegate: delegate),
            ManagedWindow(window: second, edge: .down, delegate: delegate),
        ]
        for window in managed {
            window.isLeftMousePressed = { false }
            window.dock()
        }
        for _ in 0..<20 { await Task.yield() }

        // lock → remove external displays → 0 screens → built-in display → unlock
        delegate.layout.layout = ScreenLayout(screens: [ScreenInfo]())
        let builtIn = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 1352, height: 843))
        delegate.layout.layout = ScreenLayout(screens: [builtIn])
        for window in managed {
            window.evaluate(mouseQ: .zero, mouseVelocity: .zero, frontmost: true,
                            blockedByPeeked: false, blockedBySmaller: false,
                            settling: false, now: Date())
        }

        for window in managed {
            if delegate.removed.contains(where: { $0 === window }) {
                #expect(delegate.geometry.quartzVisibleFrame(of: builtIn).contains(window.window.frame!))
            } else {
                let strip = delegate.geometry.sliverRect(edge: .down, size: window.window.frame!.size,
                                                         perp: window.perp, screen: builtIn, thickness: 15)
                #expect(delegate.geometry.quartzVisibleFrame(of: builtIn).contains(strip))
            }
        }
    }
}
