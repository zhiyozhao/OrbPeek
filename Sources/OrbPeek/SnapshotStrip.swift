import AppKit
import OrbPeekCore

// A floating strip that displays a captured slice of a docked window's content.
final class SnapshotStrip: NSPanel, SnapshotStripHandling {
    private let imageView = NSImageView()
    private var identityName = "OrbPeek"
    private var identityIcon: NSImage?

    package func setIdentity(name: String, pid: pid_t?) {
        identityName = name
        identityIcon = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
    }

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

    // The strip thickness the current image/frame was laid out with — used to
    // detect sliverPx changes and re-crop.
    package private(set) var thickness: CGFloat = 0

    package func show(image: NSImage?, frame: NSRect, edge: DockEdge) {
        hasContent = image != nil
        thickness = edge.slideAxis == .vertical ? frame.height : frame.width
        if let image {
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            imageView.layer?.backgroundColor = nil
        } else {
            // Capture genuinely unavailable (e.g. missing screen-recording
            // permission): keep the strip a visible, hoverable handle.
            imageView.image = StripIdentity.image(name: identityName, icon: identityIcon, size: frame.size, edge: edge)
            imageView.layer?.backgroundColor = nil
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
    // The radius isn't queryable; 10pt matches titlebar-only windows on
    // macOS 26 (measured from real captures; toolbar/sidebar windows use a
    // larger ~16–26pt squircle). Points are resolution-independent; no
    // display-scale handling needed. The rect is extended by 2r on the square
    // side so CGPath's radius cap (half the smaller side) never shrinks the
    // arc on thin strips.
    private func applyCornerMask(edge: DockEdge) {
        guard let bounds = contentView?.bounds, bounds.width > 0, bounds.height > 0 else { return }
        let r: CGFloat = 10
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

    package func hide() {
        hasContent = false
        orderOut(nil)
    }

    // Move/resize the strip without touching its image (e.g. the user changed
    // the strip width in settings while windows are docked).
    package func updateFrame(_ frame: NSRect, edge: DockEdge) {
        thickness = edge.slideAxis == .vertical ? frame.height : frame.width
        setFrame(frame, display: true)
        applyCornerMask(edge: edge)
    }
}

// Explicit identity card, not simulated window pixels. Rotate the legend on
// vertical edges so the app name remains readable at the configured thickness.
@MainActor
enum StripIdentity {
    static func image(name: String, icon: NSImage?, size: CGSize, edge: DockEdge) -> NSImage {
        NSImage(size: size, flipped: false) { bounds in
            NSColor.controlBackgroundColor.setFill(); bounds.fill()
            let vertical = edge.slideAxis == .horizontal
            let transform = NSAffineTransform()
            if vertical { transform.translateX(by: size.width, yBy: 0); transform.rotate(byDegrees: 90); transform.concat() }
            let thickness = vertical ? size.width : size.height
            let length = vertical ? size.height : size.width
            let iconSize = max(1, min(14, thickness - 2))
            icon?.draw(in: NSRect(x: 3, y: (thickness - iconSize) / 2, width: iconSize, height: iconSize))
            let label = name.isEmpty ? "OrbPeek" : name
            let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: max(5, min(11, thickness - 2))),
                .foregroundColor: NSColor.labelColor])
            text.draw(in: NSRect(x: icon == nil ? 4 : iconSize + 6, y: 0, width: max(1, length - iconSize - 10), height: thickness))
            return true
        }
    }
}
