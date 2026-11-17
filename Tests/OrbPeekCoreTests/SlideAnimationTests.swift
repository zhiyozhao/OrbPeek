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
        #expect(machine.begin(plan))
        #expect(!machine.begin(plan))
        machine.finish()
        #expect(machine.state == .finished)
        #expect(machine.begin(plan))
        machine.cancel()
        #expect(machine.state == .cancelled)

        let second = SlideAnimationStateMachine()
        #expect(second.begin(plan))
        second.cancel()
        #expect(second.state == .cancelled)
        second.finish()
        #expect(second.state == .cancelled)
    }

    @Test("missing image or reduce-motion bypasses animation")
    func reduceMotionFallback() {
        #expect(!SlideAnimationPlan.shouldAnimate(hasImage: false, reduceMotion: false))
        #expect(!SlideAnimationPlan.shouldAnimate(hasImage: true, reduceMotion: true))
        #expect(SlideAnimationPlan.shouldAnimate(hasImage: true, reduceMotion: false))
    }
}
