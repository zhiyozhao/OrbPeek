import AppKit

package extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

// Edge a window can dock to.
package enum DockEdge: String, Codable {
    case left, right, up, down

    package var slideAxis: Axis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    package enum Axis { case horizontal, vertical }
}

// A value snapshot of NSScreen. UUID identifies the physical display;
// display ID is only its current runtime address.
package struct ScreenInfo: Equatable {
    package let id: CGDirectDisplayID
    package let frame: CGRect
    package let visibleFrame: CGRect
    package let displayUUID: String?
    package let mirrorSourceID: CGDirectDisplayID?

    package init(id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect,
                 displayUUID: String? = nil, mirrorSourceID: CGDirectDisplayID? = nil) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.displayUUID = displayUUID
        self.mirrorSourceID = mirrorSourceID
    }

    package init(_ screen: NSScreen) {
        self.id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            self.displayUUID = CFUUIDCreateString(nil, uuid) as String
        } else { self.displayUUID = nil }
        let source = CGDisplayMirrorsDisplay(id)
        self.mirrorSourceID = source == kCGNullDirectDisplay ? nil : source
    }
}

// NSScreen.screens[0] is the primary display and defines the CG/AX origin.
package struct ScreenLayout: Equatable {
    package let screens: [ScreenInfo]

    package init(screens: [ScreenInfo]) {
        // Mirror receivers do not add a separate reachable desktop.
        self.screens = screens.filter { $0.mirrorSourceID == nil }
    }

    package init(screens: [NSScreen]) {
        self.init(screens: screens.map(ScreenInfo.init))
    }

    package var primary: ScreenInfo? { screens.first }

    package var isValid: Bool {
        !screens.isEmpty && Set(screens.map(\.id)).count == screens.count && screens.allSatisfy {
            [$0.frame, $0.visibleFrame].allSatisfy { rect in
                [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) &&
                    rect.width > 0 && rect.height > 0
            }
        }
    }

    // UUIDs must match uniquely. Never guess identity from model or resolution.
    package func matchingScreen(id: CGDirectDisplayID?, uuid: String?) -> ScreenInfo? {
        if let uuid {
            let matches = screens.filter { $0.displayUUID == uuid }
            return matches.count == 1 ? matches[0] : nil
        }
        return screens.first { $0.id == id && $0.displayUUID == nil }
    }

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
    // CG/AX global coordinates use the primary display's top-left as origin.
    // The desktop union is only valid for choosing outer parking edges.
    private var primaryMaxY: CGFloat { layout.primary?.frame.maxY ?? 0 }

    // AppKit (bottom-left) point -> quartz (top-left) point.
    package func toQuartz(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryMaxY - p.y)
    }

    // Quartz rect -> AppKit rect (for positioning our own floating panels).
    package func toAppKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    package func quartzVisibleFrame(of screen: ScreenInfo) -> CGRect {
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: primaryMaxY - v.maxY, width: v.width, height: v.height)
    }

    package func quartzFrame(of screen: ScreenInfo) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
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

    // Largest visible intersection wins. For a fully off-screen window, use
    // Euclidean rectangle distance so an unplugged display never strands it.
    package func nearestScreen(to frame: CGRect) -> ScreenInfo? {
        if let containing = screen(containing: frame) {
            let intersection = quartzVisibleFrame(of: containing).intersection(frame)
            if !intersection.isNull && !intersection.isEmpty { return containing }
        }
        var nearest: ScreenInfo?
        var nearestDistance = CGFloat.infinity
        for screen in layout.screens {
            let visible = quartzVisibleFrame(of: screen)
            let dx = max(max(visible.minX - frame.maxX, frame.minX - visible.maxX), 0)
            let dy = max(max(visible.minY - frame.maxY, frame.minY - visible.maxY), 0)
            let distance = dx * dx + dy * dy
            if distance < nearestDistance { nearest = screen; nearestDistance = distance }
        }
        return nearest ?? layout.primary
    }

    package func fitting(_ frame: CGRect, in screen: ScreenInfo) -> CGRect {
        let visible = quartzVisibleFrame(of: screen)
        guard visible.width > 0, visible.height > 0 else { return frame }
        let size = CGSize(width: min(max(frame.width, 1), visible.width),
                          height: min(max(frame.height, 1), visible.height))
        let x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    package func visibleFraction(of frame: CGRect) -> CGFloat {
        guard frame.width > 0, frame.height > 0, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return 0 }
        let rects = layout.screens.map { quartzVisibleFrame(of: $0).intersection(frame) }.filter { !$0.isNull && !$0.isEmpty }
        let xs = Set(rects.flatMap { [$0.minX, $0.maxX] }).sorted()
        var area: CGFloat = 0
        for (left, right) in zip(xs, xs.dropFirst()) {
            var end = -CGFloat.infinity
            var height: CGFloat = 0
            for rect in rects.filter({ $0.minX < right && $0.maxX > left }).sorted(by: { $0.minY < $1.minY }) {
                height += max(0, rect.maxY - max(end, rect.minY))
                end = max(end, rect.maxY)
            }
            area += (right - left) * height
        }
        return area / (frame.width * frame.height)
    }

    package func isOuterEdge(_ edge: DockEdge, of screen: ScreenInfo) -> Bool {
        let frame = quartzFrame(of: screen)
        return !layout.screens.contains { other in
            guard other.id != screen.id else { return false }
            let adjacent = quartzFrame(of: other)
            switch edge {
            case .left: return adjacent.minX < frame.minX && adjacent.maxX >= frame.minX - 0.5 && min(adjacent.maxY, frame.maxY) - max(adjacent.minY, frame.minY) > 0.5
            case .right: return adjacent.maxX > frame.maxX && adjacent.minX <= frame.maxX + 0.5 && min(adjacent.maxY, frame.maxY) - max(adjacent.minY, frame.minY) > 0.5
            case .up: return adjacent.minY < frame.minY && adjacent.maxY >= frame.minY - 0.5 && min(adjacent.maxX, frame.maxX) - max(adjacent.minX, frame.minX) > 0.5
            case .down: return adjacent.maxY > frame.maxY && adjacent.minY <= frame.maxY + 0.5 && min(adjacent.maxX, frame.maxX) - max(adjacent.minX, frame.minX) > 0.5
            }
        }
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

    // Stored coordinates are relative to the recorded screen, so changing the
    // primary display or global origin cannot change their physical meaning.
    package func dockPerpOffset(for edge: DockEdge, frame: CGRect, screen: ScreenInfo) -> CGFloat {
        let v = quartzVisibleFrame(of: screen)
        switch edge.slideAxis {
        case .horizontal: return frame.minY - v.minY
        case .vertical: return frame.minX - v.minX
        }
    }

    package func absolutePerp(for edge: DockEdge, perpOffset: CGFloat, screen: ScreenInfo) -> CGFloat {
        let v = quartzVisibleFrame(of: screen)
        switch edge.slideAxis {
        case .horizontal: return v.minY + perpOffset
        case .vertical: return v.minX + perpOffset
        }
    }

    package func hiddenPosition(for edge: DockEdge, size: CGSize, perp storedPerp: CGFloat, screen: ScreenInfo) -> CGPoint {
        let v = quartzVisibleFrame(of: screen)
        let perp = absolutePerp(for: edge, perpOffset: storedPerp, screen: screen)
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

    package func peekPosition(for edge: DockEdge, size: CGSize, perp storedPerp: CGFloat, screen: ScreenInfo) -> CGPoint? {
        let v = quartzVisibleFrame(of: screen)
        let perp = absolutePerp(for: edge, perpOffset: storedPerp, screen: screen)
        switch edge {
        case .left: return CGPoint(x: v.minX, y: clamped(perp, lo: v.minY, hi: v.maxY - size.height))
        case .right: return CGPoint(x: v.maxX - size.width, y: clamped(perp, lo: v.minY, hi: v.maxY - size.height))
        case .up: return CGPoint(x: clamped(perp, lo: v.minX, hi: v.maxX - size.width), y: v.minY)
        case .down: return CGPoint(x: clamped(perp, lo: v.minX, hi: v.maxX - size.width), y: v.maxY - size.height)
        }
    }

    package func sliverRect(edge: DockEdge, size: CGSize, perp storedPerp: CGFloat, screen: ScreenInfo, thickness: CGFloat) -> CGRect {
        let v = quartzVisibleFrame(of: screen)
        let perp = absolutePerp(for: edge, perpOffset: storedPerp, screen: screen)
        switch edge {
        case .left: return CGRect(x: v.minX, y: clamped(perp, lo: v.minY, hi: v.maxY - size.height), width: thickness, height: size.height)
        case .right: return CGRect(x: v.maxX - thickness, y: clamped(perp, lo: v.minY, hi: v.maxY - size.height), width: thickness, height: size.height)
        case .up: return CGRect(x: clamped(perp, lo: v.minX, hi: v.maxX - size.width), y: v.minY, width: size.width, height: thickness)
        case .down: return CGRect(x: clamped(perp, lo: v.minX, hi: v.maxX - size.width), y: v.maxY - thickness, width: size.width, height: thickness)
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
