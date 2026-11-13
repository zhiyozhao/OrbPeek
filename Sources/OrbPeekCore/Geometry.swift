import AppKit

// Edge a window can dock to.
package enum DockEdge {
    case left, right, up, down

    package var slideAxis: Axis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    package enum Axis { case horizontal, vertical }
}

// A value-type snapshot of NSScreen. Display ID, rather than an NSScreen
// object, is the stable identity across screen-parameter notifications.
package struct ScreenInfo: Equatable {
    package let id: CGDirectDisplayID
    package let frame: CGRect
    package let visibleFrame: CGRect

    package init(id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    package init(_ screen: NSScreen) {
        self.id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
    }
}

// NSScreen.screens[0] is the primary display and defines the CG/AX origin.
package struct ScreenLayout: Equatable {
    package let screens: [ScreenInfo]

    package init(screens: [ScreenInfo]) {
        self.screens = screens
    }

    package init(screens: [NSScreen]) {
        self.init(screens: screens.map(ScreenInfo.init))
    }

    package var primary: ScreenInfo? { screens.first }

    package var desktopFrame: CGRect {
        guard let first = screens.first else { return .zero }
        return screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }
}

// Pure geometry over an injectable screen layout. Production reads the current
// NSScreen list on every access; tests provide fixed layouts without AppKit
// global state. AX frames are quartz (top-left); AppKit is bottom-left.
package struct WindowGeometry {
    private let layoutProvider: () -> ScreenLayout

    package init() {
        self.layoutProvider = { ScreenLayout(screens: NSScreen.screens) }
    }

    package init(layout: ScreenLayout) {
        self.layoutProvider = { layout }
    }

    package init(layoutProvider: @escaping () -> ScreenLayout) {
        self.layoutProvider = layoutProvider
    }

    package var layout: ScreenLayout { layoutProvider() }
    private var desktopFrame: CGRect { layout.desktopFrame }

    // AppKit (bottom-left) point -> quartz (top-left) point.
    package func toQuartz(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - desktopFrame.minX, y: desktopFrame.maxY - p.y)
    }

    // Quartz rect -> AppKit rect (for positioning our own floating panels).
    package func toAppKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: desktopFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    package func quartzVisibleFrame(of screen: ScreenInfo) -> CGRect {
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: desktopFrame.maxY - v.maxY, width: v.width, height: v.height)
    }

    package func quartzFrame(of screen: ScreenInfo) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: desktopFrame.maxY - f.maxY, width: f.width, height: f.height)
    }

    private func clamped(_ p: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        min(max(p, lo), max(lo, hi))
    }

    // Largest quartz-frame intersection wins; an absent screen falls back to
    // the primary display, never NSScreen.main (which tracks keyboard focus).
    package func screen(containing frame: CGRect) -> ScreenInfo? {
        var best: ScreenInfo?
        var bestArea: CGFloat = 0
        for screen in layout.screens {
            let intersection = quartzFrame(of: screen).intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea { best = screen; bestArea = area }
        }
        if let best { return best }
        return layout.screens.first { quartzFrame(of: $0).contains(frame.origin) } ?? layout.primary
    }

    package func screen(withDisplayID id: CGDirectDisplayID) -> ScreenInfo? {
        layout.screens.first { $0.id == id }
    }

    package func sliceScreenRect(edge: DockEdge, frame: CGRect, thickness: CGFloat) -> CGRect {
        switch edge {
        case .up: return CGRect(x: frame.minX, y: frame.maxY - thickness, width: frame.width, height: thickness)
        case .down: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: thickness)
        case .left: return CGRect(x: frame.maxX - thickness, y: frame.minY, width: thickness, height: frame.height)
        case .right: return CGRect(x: frame.minX, y: frame.minY, width: thickness, height: frame.height)
        }
    }

    package func dockPerp(for edge: DockEdge, frame: CGRect) -> CGFloat {
        switch edge.slideAxis {
        case .horizontal: return frame.minY
        case .vertical: return frame.minX
        }
    }

    package func hiddenPosition(for edge: DockEdge, size: CGSize, perp: CGFloat, screen: ScreenInfo) -> CGPoint {
        let v = quartzVisibleFrame(of: screen)
        let y: CGFloat
        switch edge {
        case .up: y = v.minY
        case .down: y = v.maxY - size.height
        case .left, .right: y = clamped(perp, lo: v.minY, hi: v.maxY - size.height)
        }
        if screen.frame.maxX >= desktopFrame.maxX - 0.5 {
            return CGPoint(x: desktopFrame.maxX - 1, y: y)
        }
        if screen.frame.minX <= desktopFrame.minX + 0.5 {
            return CGPoint(x: desktopFrame.minX - size.width + 1, y: y)
        }
        return CGPoint(x: desktopFrame.maxX - 1, y: y)
    }

    package func peekPosition(for edge: DockEdge, size: CGSize, perp: CGFloat, screen: ScreenInfo) -> CGPoint? {
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return CGPoint(x: v.minX, y: clamped(perp, lo: v.minY, hi: v.maxY - size.height))
        case .right: return CGPoint(x: v.maxX - size.width, y: clamped(perp, lo: v.minY, hi: v.maxY - size.height))
        case .up: return CGPoint(x: clamped(perp, lo: v.minX, hi: v.maxX - size.width), y: v.minY)
        case .down: return CGPoint(x: clamped(perp, lo: v.minX, hi: v.maxX - size.width), y: v.maxY - size.height)
        }
    }

    package func sliverRect(edge: DockEdge, size: CGSize, perp: CGFloat, screen: ScreenInfo, thickness: CGFloat) -> CGRect {
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return CGRect(x: v.minX, y: perp, width: thickness, height: size.height)
        case .right: return CGRect(x: v.maxX - thickness, y: perp, width: thickness, height: size.height)
        case .up: return CGRect(x: perp, y: v.minY, width: size.width, height: thickness)
        case .down: return CGRect(x: perp, y: v.maxY - thickness, width: size.width, height: thickness)
        }
    }

    package func distanceFromDockEdge(_ frame: CGRect, edge: DockEdge, screen: ScreenInfo) -> CGFloat {
        let v = quartzVisibleFrame(of: screen)
        switch edge {
        case .left: return frame.minX - v.minX
        case .right: return v.maxX - frame.maxX
        case .up: return frame.minY - v.minY
        case .down: return v.maxY - frame.maxY
        }
    }
}
