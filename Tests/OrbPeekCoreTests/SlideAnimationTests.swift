import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("slide animation plan and state machine")
@MainActor
struct SlideAnimationTests {
    let start = CGRect(x: 100, y: 100, width: 600, height: 400)
    let end = CGRect(x: 800, y: 600, width: 20, height: 400)

    @Test("dock plan uses 150ms ease-out and all four edges preserve the plan")
    func geometry() {
        for edge in [DockEdge.left, .right, .up, .down] {
            let plan = SlideAnimationPlan.dock(windowFrame: start, stripFrame: end, edge: edge)
            #expect(plan.duration == 0.15)
            #expect(plan.frame(at: 0) == start)
            #expect(plan.frame(at: 1) == end)
            #expect(plan.frame(at: 0.5).minX == 625)
        }
    }

    @Test("overlay covers the full animation path in local coordinates")
    func overlayGeometry() {
        for edge in [DockEdge.left, .right, .up, .down] {
            let plan = SlideAnimationPlan.dock(windowFrame: start, stripFrame: end, edge: edge)
            let layout = SlideOverlayGeometry(plan: plan)
            #expect(layout.panelFrame == start.union(end))
            #expect(layout.layerStartFrame == start.offsetBy(dx: -layout.panelFrame.minX, dy: -layout.panelFrame.minY))
            #expect(layout.layerEndFrame == end.offsetBy(dx: -layout.panelFrame.minX, dy: -layout.panelFrame.minY))
            #expect(layout.panelFrame.contains(layout.layerEndFrame))
            #expect(layout.layerEndFrame.origin.x >= 0)
            #expect(layout.layerEndFrame.origin.y >= 0)
        }
    }

    @Test("peek plan goes from strip to the real window target")
    func peekGeometry() {
        let plan = SlideAnimationPlan.peek(stripFrame: end, windowFrame: start, edge: .right)
        #expect(plan.startFrame == end)
        #expect(plan.endFrame == start)
        #expect(plan.frame(at: 0.5).minX == 275)
    }

    @Test("start, finish and cancel are exclusive")
    func lifecycle() {
        let machine = SlideAnimationStateMachine()
        let plan = SlideAnimationPlan.dock(windowFrame: start, stripFrame: end, edge: .down)
        let first = machine.begin(plan)
        #expect(first != nil)
        #expect(machine.begin(plan) == nil)
        machine.finish(first!)
        #expect(machine.state == .finished)
        let nextID = machine.begin(plan)
        #expect(nextID != nil)
        machine.cancel(nextID!)
        #expect(machine.state == .cancelled)

        let second = SlideAnimationStateMachine()
        let secondID = second.begin(plan)
        #expect(secondID != nil)
        second.cancel(secondID!)
        #expect(second.state == .cancelled)
        second.finish(secondID!)
        #expect(second.state == .cancelled)
    }

    @Test("an old completion cannot finish a newer animation")
    func staleCompletionIsIgnored() {
        let machine = SlideAnimationStateMachine()
        let oldID = machine.begin(SlideAnimationPlan.dock(windowFrame: start, stripFrame: end, edge: .down))!
        machine.cancel(oldID)
        let newID = machine.begin(SlideAnimationPlan.peek(stripFrame: end, windowFrame: start, edge: .down))!
        machine.finish(oldID)
        machine.cancel(oldID)
        #expect(machine.state == .running(SlideAnimationPlan.peek(stripFrame: end, windowFrame: start, edge: .down), newID))
    }

    @Test("missing image or reduce-motion bypasses animation")
    func reduceMotionFallback() {
        #expect(!SlideAnimationPlan.shouldAnimate(hasImage: false, reduceMotion: false))
        #expect(!SlideAnimationPlan.shouldAnimate(hasImage: true, reduceMotion: true))
        #expect(SlideAnimationPlan.shouldAnimate(hasImage: true, reduceMotion: false))
    }
}
