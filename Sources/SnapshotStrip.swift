import AppKit

// A floating strip that displays a captured slice of a docked window's content.
final class SnapshotStrip: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Hover/peek is detected geometrically by the poll, so the strip must not
        // swallow clicks aimed at whatever is below it.
        ignoresMouseEvents = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        contentView = imageView
    }

    // Whether the strip is currently showing a captured image (vs placeholder
    // or hidden) — used to decide if a delayed placeholder is still needed.
    private(set) var hasContent = false

    // The currently displayed capture, if any.
    var image: NSImage? { imageView.image }

    func show(image: NSImage?, frame: NSRect, edge: DockEdge) {
        hasContent = image != nil
        if let image {
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            imageView.layer?.backgroundColor = nil
        } else {
            // Capture genuinely unavailable (e.g. missing screen-recording
            // permission): keep the strip a visible, hoverable handle.
            imageView.image = nil
            imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        }
        setFrame(frame, display: true)
        applyCornerMask(edge: edge)
        orderFrontRegardless()
    }

    // Real windows have rounded corners, so the captured slice's corner pixels
    // are whatever was behind the window at capture time — they show up as
    // dark blocks when the strip is displayed at the edge. Clip the corners
    // that correspond to the window's rounded corners so the live backdrop
    // shows through, like a real window edge.
    //
    // The radius isn't queryable; 18pt is a middle ground between titlebar
    // windows (~16pt on macOS 26) and toolbar/sidebar windows (20–26pt) —
    // over-clipping hides uniform edge content, under-clipping leaves dark
    // backdrop remnants, so err on the larger side. Points are resolution-
    // independent; no display-scale handling needed. The rect is extended by
    // 2r on the square side so CGPath's radius cap (half the smaller side)
    // never shrinks the arc on thin strips.
    private func applyCornerMask(edge: DockEdge) {
        guard let bounds = contentView?.bounds, bounds.width > 0, bounds.height > 0 else { return }
        let r: CGFloat = 18
        var rect = bounds
        switch edge {
        case .up: rect.size.height += 2 * r // window's bottom edge -> round bottom corners
        case .down: rect.origin.y -= 2 * r; rect.size.height += 2 * r // title bar -> round top corners
        case .left: rect.origin.x -= 2 * r; rect.size.width += 2 * r // window's right edge -> round right corners
        case .right: rect.size.width += 2 * r // window's left edge -> round left corners
        }
        let mask = CAShapeLayer()
        mask.path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        imageView.layer?.mask = mask
    }

    func hide() {
        hasContent = false
        orderOut(nil)
    }
}
