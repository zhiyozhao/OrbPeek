import AppKit

// Edge a window can be docked to. A docked window is parked off the desktop's
// right outer edge with 1px visible (macOS keeps titled windows from leaving
// the screen in other directions), and a captured strip (`SnapshotStrip`,
// always floating above other windows) is the handle.
enum DockEdge {
    case left, right, up, down

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

    // A screen's full frame in quartz coordinates.
    func quartzFrame(of screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: desktopFrame.maxY - f.maxY, width: f.width, height: f.height)
    }

    // The screen a quartz frame mostly sits on (largest intersection; falls
    // back to origin containment, then the main screen).
    func screen(containing frame: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for s in NSScreen.screens {
            let inter = quartzFrame(of: s).intersection(frame)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea { best = s; bestArea = area }
        }
        if let best { return best }
        return NSScreen.screens.first { quartzFrame(of: $0).contains(frame.origin) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    // Stable identity for a screen (survives NSScreen object churn).
    func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    func screen(withDisplayID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    // The screen region (quartz) a slice is captured from, for the window's
    // current on-screen frame. Slice choice mimics the window really sliding
    // off the edge: up -> bottom slice, down -> title bar, left -> right edge,
    // right -> left edge.
    func sliceScreenRect(edge: DockEdge, frame: CGRect, thickness: CGFloat) -> CGRect {
        switch edge {
        case .up: return CGRect(x: frame.minX, y: frame.maxY - thickness, width: frame.width, height: thickness)
        case .down: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: thickness)
        case .left: return CGRect(x: frame.maxX - thickness, y: frame.minY, width: thickness, height: frame.height)
        case .right: return CGRect(x: frame.minX, y: frame.minY, width: thickness, height: frame.height)
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

    // Where the window sits while hidden: parked off a desktop outer edge with
    // 1px visible (macOS keeps ~40px visible if fully off, but allows 1px).
    // The 1px stays on the DOCK screen whenever possible — park off the
    // desktop's right edge when the dock screen is rightmost, off the left
    // edge when it's leftmost — so the window's screen ownership never
    // changes. y matches the peek position so the window only slides
    // horizontally when recalled.
    func hiddenPosition(for edge: DockEdge, size: CGSize, perp: CGFloat, screen: NSScreen) -> CGPoint {
        let v = quartzVisibleFrame(of: screen)
        let y: CGFloat
        switch edge {
        case .up: y = v.minY
        case .down: y = v.maxY - size.height
        case .left, .right: y = perp
        }
        if screen.frame.maxX >= desktopFrame.maxX - 0.5 {
            return CGPoint(x: desktopFrame.maxX - 1, y: y)
        }
        if screen.frame.minX <= desktopFrame.minX + 0.5 {
            return CGPoint(x: desktopFrame.minX - size.width + 1, y: y)
        }
        // Middle screen in a 3+ display row: no desktop edge of its own —
        // fall back to the right edge.
        return CGPoint(x: desktopFrame.maxX - 1, y: y)
    }

    // Flush position the window slides back to when peeked.
    func peekPosition(for edge: DockEdge, size: CGSize, perp: CGFloat, screen: NSScreen) -> CGPoint? {
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return CGPoint(x: v.minX, y: perp)
        case .right: return CGPoint(x: v.maxX - size.width, y: perp)
        case .up: return CGPoint(x: perp, y: v.minY)
        case .down: return CGPoint(x: perp, y: v.maxY - size.height)
        }
    }

    // The handle rect (what you hover to peek): the window's own slice for
    // real left/right (thickness = sliverPx), or the fake strip's frame for
    // fake edges (thickness = fakeSliverPx).
    func sliverRect(edge: DockEdge, size: CGSize, perp: CGFloat, screen: NSScreen, thickness: CGFloat) -> CGRect {
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return CGRect(x: v.minX, y: perp, width: thickness, height: size.height)
        case .right: return CGRect(x: v.maxX - thickness, y: perp, width: thickness, height: size.height)
        case .up: return CGRect(x: perp, y: v.minY, width: size.width, height: thickness)
        case .down: return CGRect(x: perp, y: v.maxY - thickness, width: size.width, height: thickness)
        }
    }

    // How far a window's docked-side edge sits off its docked edge (used to
    // decide whether the user dragged it out of the dock).
    func distanceFromDockEdge(_ frame: CGRect, edge: DockEdge, screen: NSScreen) -> CGFloat {
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return frame.minX - v.minX
        case .right: return v.maxX - frame.maxX
        case .up: return frame.minY - v.minY
        case .down: return v.maxY - frame.maxY
        }
    }
}
