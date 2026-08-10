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
        imageView.layer?.cornerRadius = 2
        imageView.layer?.masksToBounds = true
        contentView = imageView
    }

    // Whether the strip is currently showing a captured image (vs placeholder
    // or hidden) — used to decide if a delayed placeholder is still needed.
    private(set) var hasContent = false

    func show(image: NSImage?, frame: NSRect) {
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
        orderFrontRegardless()
    }

    func hide() {
        hasContent = false
        orderOut(nil)
    }
}
