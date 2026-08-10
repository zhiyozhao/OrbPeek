import AppKit

// Edge a window can be docked to. macOS keeps a titled window's title bar
// on-screen, so the top/bottom edges use a fake snapshot sliver as the handle
// (left/right use the window's own visible slice).
enum DockEdge {
    case left, right, up, down

    var isFake: Bool { self == .up || self == .down }

    // The axis the window is moved along when docking/peeking.
    var slideAxis: Axis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    enum Axis { case horizontal, vertical }
}

// Pure geometry: converts between coordinate spaces and computes dock/peek
// positions. AX frames are quartz (top-left origin); NSScreen frames and
// NSEvent.mouseLocation are AppKit (bottom-left origin). All conversions live
// here so the space mix-up can't leak into callers.
struct WindowGeometry {
    // The union of all screens' frames in AppKit coordinates.
    private var desktopFrame: CGRect {
        guard let first = NSScreen.screens.first else { return .zero }
        var r = first.frame
        for s in NSScreen.screens.dropFirst() { r = r.union(s.frame) }
        return r
    }

    // AppKit (bottom-left) point -> quartz (top-left) point.
    func toQuartz(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - desktopFrame.minX, y: desktopFrame.maxY - p.y)
    }

    // Quartz rect -> AppKit rect (for positioning our own floating panels).
    func toAppKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: desktopFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    // An NSScreen's visible frame in quartz coordinates.
    func quartzVisibleFrame(of screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: desktopFrame.maxY - v.maxY, width: v.width, height: v.height)
    }

    // The screen at the desktop's outer edge in the dock direction. For up/down
    // this is the screen under the window's perpendicular (x), resolved in
    // quartz space so multi-monitor origin offsets can't pick the wrong screen.
    func outerScreen(for edge: DockEdge, perp: CGFloat) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        switch edge {
        case .left: return screens.min { $0.frame.minX < $1.frame.minX }
        case .right: return screens.max { $0.frame.maxX < $1.frame.maxX }
        case .up, .down:
            let appKitX = perp + desktopFrame.minX
            return screens.first { $0.frame.contains(CGPoint(x: appKitX, y: $0.frame.midY)) }
                ?? NSScreen.main ?? screens.first
        }
    }

    // The perpendicular coordinate to preserve for an edge (y for left/right,
    // x for up/down).
    func dockPerp(for edge: DockEdge, frame: CGRect) -> CGFloat {
        switch edge.slideAxis {
        case .horizontal: return frame.minY
        case .vertical: return frame.minX
        }
    }

    // The window's size along the sliver (height for left/right, width for
    // up/down) — used to pick the smallest window when slivers overlap.
    func sliverLength(edge: DockEdge, size: CGSize) -> CGFloat {
        switch edge.slideAxis {
        case .horizontal: return size.height
        case .vertical: return size.width
        }
    }

    // Where the window sits while hidden, for any edge:
    // - LEFT/RIGHT: mostly past the outer edge, leaving `sliver` px of the
    //   window visible (the handle).
    // - UP/DOWN: the real window tucks off the desktop's right outer edge
    //   leaving a 1px sliver (macOS keeps ~40px visible if fully off, but
    //   allows 1px). The fake strip at the top/bottom is the real handle; its
    //   y matches the peek position so the window only slides horizontally
    //   when recalled.
    func hiddenPosition(for edge: DockEdge, size: CGSize, perp: CGFloat, sliver: CGFloat) -> CGPoint? {
        guard let screen = outerScreen(for: edge, perp: perp) else { return nil }
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return CGPoint(x: v.minX - size.width + sliver, y: perp)
        case .right: return CGPoint(x: v.maxX - sliver, y: perp)
        case .up: return CGPoint(x: desktopFrame.maxX - 1, y: v.minY)
        case .down: return CGPoint(x: desktopFrame.maxX - 1, y: v.maxY - size.height)
        }
    }

    // Flush position the window slides back to when peeked.
    func peekPosition(for edge: DockEdge, size: CGSize, perp: CGFloat) -> CGPoint? {
        guard let screen = outerScreen(for: edge, perp: perp) else { return nil }
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return CGPoint(x: v.minX, y: perp)
        case .right: return CGPoint(x: v.maxX - size.width, y: perp)
        case .up: return CGPoint(x: perp, y: v.minY)
        case .down: return CGPoint(x: perp, y: v.maxY - size.height)
        }
    }

    // The handle rect (what you hover to peek): the window's own slice for
    // left/right, or the fake snapshot strip's frame for up/down.
    func sliverRect(edge: DockEdge, size: CGSize, perp: CGFloat, sliver: CGFloat, fakeSliver: CGFloat) -> CGRect {
        guard let screen = outerScreen(for: edge, perp: perp) else { return .zero }
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return CGRect(x: v.minX, y: perp, width: sliver, height: size.height)
        case .right: return CGRect(x: v.maxX - sliver, y: perp, width: sliver, height: size.height)
        case .up: return CGRect(x: perp, y: v.minY, width: size.width, height: fakeSliver)
        case .down: return CGRect(x: perp, y: v.maxY - fakeSliver, width: size.width, height: fakeSliver)
        }
    }

    // How far a window's docked-side edge sits off its docked edge (used to
    // decide whether the user dragged it out of the dock).
    func distanceFromDockEdge(_ frame: CGRect, edge: DockEdge) -> CGFloat? {
        guard let screen = outerScreen(for: edge, perp: frame.minX) else { return nil }
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return frame.minX - v.minX
        case .right: return v.maxX - frame.maxX
        case .up: return frame.minY - v.minY
        case .down: return v.maxY - frame.maxY
        }
    }
}
