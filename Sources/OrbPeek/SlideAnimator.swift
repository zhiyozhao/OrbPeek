import AppKit
import QuartzCore
import OrbPeekCore

@MainActor
private final class SlideOverlayPanel: NSPanel {
    private let imageView = NSImageView()

    init(image: NSImage, frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        contentView = imageView
        contentView?.wantsLayer = true
        imageView.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
}

@MainActor
final class SlideAnimator: SlideAnimating {
    private let stateMachine = SlideAnimationStateMachine()
    private var panel: SlideOverlayPanel?
    private var completion: ((Bool) -> Void)?
    private var activeID: Int?

    func play(image: NSImage, plan: SlideAnimationPlan, completion: @escaping (Bool) -> Void) -> Bool {
        guard let id = stateMachine.begin(plan) else {
            completion(false)
            return false
        }
        activeID = id
        self.completion = completion
        let layout = SlideOverlayGeometry(plan: plan)
        let panel = SlideOverlayPanel(image: image, frame: layout.panelFrame)
        self.panel = panel
        let layer = panel.contentView!.layer!
        layer.frame = layout.layerStartFrame
        panel.orderFrontRegardless()

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: layout.layerStartFrame.midX, y: layout.layerStartFrame.midY))
        position.toValue = NSValue(point: CGPoint(x: layout.layerEndFrame.midX, y: layout.layerEndFrame.midY))
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: layer.bounds)
        bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: layout.layerEndFrame.size))
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = plan.kind == .dock ? 1 : 0.65
        opacity.toValue = plan.kind == .dock ? 0.25 : 1
        let group = CAAnimationGroup()
        group.animations = [position, bounds, opacity]
        group.duration = plan.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak panel] in
            guard let self, self.activeID == id else { return }
            self.stateMachine.finish(id)
            // Complete the real-window handoff before removing the overlay.
            self.completion?(true)
            self.completion = nil
            self.activeID = nil
            panel?.orderOut(nil)
            self.panel = nil
        }
        panel.contentView?.layer?.add(group, forKey: "orbpeek-slide")
        CATransaction.commit()
        return true
    }

    func cancel() {
        guard panel != nil else { return }
        panel?.contentView?.layer?.removeAllAnimations()
        if let activeID { stateMachine.cancel(activeID) }
        completion?(false)
        completion = nil
        activeID = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
