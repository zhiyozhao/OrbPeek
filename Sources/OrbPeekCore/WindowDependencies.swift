import AppKit

// The state machine talks to this narrow interface instead of AXUIElement.
// Tests can therefore simulate window-server mutations and slow AX reads.
package protocol WindowHandle: AnyObject {
    var frame: CGRect? { get }
    var position: CGPoint? { get set }
    var isMinimized: Bool { get }
    var isAppHidden: Bool { get }
    var pid: pid_t? { get }
    var title: String? { get }
    var bundleIdentifier: String? { get }
    func unminimize()
    func raise()
    func activate()
    func resize(to size: CGSize)
    func isSameWindow(as other: any WindowHandle) -> Bool
}

package struct DockConfiguration {
    package var edgeBuffer: CGFloat
    package var sliverPx: CGFloat
    package var peekDwell: Double
    package var touchDwell: Double
    package var dockCancelPx: CGFloat
    package var slamVelocity: Double
    package var stripOpacity: Double

    package init(edgeBuffer: CGFloat = 12, sliverPx: CGFloat = 15, peekDwell: Double = 0.15,
                 touchDwell: Double = 0.3, dockCancelPx: CGFloat = 40, slamVelocity: Double = 1200,
                 stripOpacity: Double = 0.5) {
        self.edgeBuffer = edgeBuffer
        self.sliverPx = sliverPx
        self.peekDwell = peekDwell
        self.touchDwell = touchDwell
        self.dockCancelPx = dockCancelPx
        self.slamVelocity = slamVelocity
        self.stripOpacity = stripOpacity
    }
}

@MainActor
package protocol SliceCapturing: AnyObject {
    func windowID(for pid: pid_t, matching frame: CGRect) -> CGWindowID?
    func windowExists(_ id: CGWindowID) -> Bool
    func cachedSlice(for windowID: CGWindowID, edge: DockEdge, size: CGSize, thickness: CGFloat) -> NSImage?
    func captureWindow(frame: CGRect, displayID: CGDirectDisplayID?, windowID: CGWindowID?) async -> CGImage?
    func slice(from image: CGImage, edge: DockEdge, windowSize: CGSize, thickness: CGFloat) -> NSImage?
}

@MainActor
package protocol SnapshotStripHandling: AnyObject {
    var frame: NSRect { get }
    var thickness: CGFloat { get }
    var alphaValue: CGFloat { get set }
    var level: NSWindow.Level { get set }
    var isVisible: Bool { get }
    func show(image: NSImage?, frame: NSRect, edge: DockEdge)
    func updateFrame(_ frame: NSRect, edge: DockEdge)
    func hide()
}
