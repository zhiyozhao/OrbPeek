import AppKit

package enum SlideAnimationKind { case dock, peek }

// Coordinates are AppKit because the overlay is an NSWindow, not an AX window.
package struct SlideAnimationPlan: Equatable {
    package let kind: SlideAnimationKind
    package let edge: DockEdge
    package let startFrame: CGRect
    package let endFrame: CGRect
    package let duration: TimeInterval

    package init(kind: SlideAnimationKind, edge: DockEdge, startFrame: CGRect, endFrame: CGRect,
                 duration: TimeInterval = 0.15) {
        self.kind = kind
        self.edge = edge
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.duration = duration
    }

    package static func dock(windowFrame: CGRect, stripFrame: CGRect, edge: DockEdge) -> SlideAnimationPlan {
        SlideAnimationPlan(kind: .dock, edge: edge, startFrame: windowFrame, endFrame: stripFrame)
    }

    package static func peek(stripFrame: CGRect, windowFrame: CGRect, edge: DockEdge) -> SlideAnimationPlan {
        SlideAnimationPlan(kind: .peek, edge: edge, startFrame: stripFrame, endFrame: windowFrame)
    }

    package func frame(at progress: CGFloat) -> CGRect {
        let t = min(max(progress, 0), 1)
        let eased = 1 - (1 - t) * (1 - t)
        return CGRect(x: startFrame.minX + (endFrame.minX - startFrame.minX) * eased,
                      y: startFrame.minY + (endFrame.minY - startFrame.minY) * eased,
                      width: startFrame.width + (endFrame.width - startFrame.width) * eased,
                      height: startFrame.height + (endFrame.height - startFrame.height) * eased)
    }

    package static func shouldAnimate(hasImage: Bool, reduceMotion: Bool) -> Bool {
        hasImage && !reduceMotion
    }
}

package struct SlideOverlayGeometry: Equatable {
    package let panelFrame: CGRect
    package let layerStartFrame: CGRect
    package let layerEndFrame: CGRect

    package init(plan: SlideAnimationPlan) {
        panelFrame = plan.startFrame.union(plan.endFrame)
        layerStartFrame = plan.startFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        layerEndFrame = plan.endFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
    }
}

@MainActor
package final class SlideAnimationStateMachine {
    package enum State: Equatable {
        case idle
        case running(SlideAnimationPlan)
        case finished
        case cancelled
    }
    package private(set) var state: State = .idle
    package init() {}

    package func begin(_ plan: SlideAnimationPlan) -> Bool {
        switch state {
        case .idle, .finished, .cancelled:
            state = .running(plan)
            return true
        case .running:
            return false
        }
    }

    package func cancel() {
        guard case .running = state else { return }
        state = .cancelled
    }

    package func finish() {
        guard case .running = state else { return }
        state = .finished
    }
}

@MainActor
package protocol SlideAnimating: AnyObject {
    @discardableResult
    func play(image: NSImage, plan: SlideAnimationPlan, completion: @escaping (Bool) -> Void) -> Bool
    func cancel()
}
