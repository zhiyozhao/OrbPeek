import AppKit
import CoreGraphics
import Testing
@testable import OrbPeekCore

@MainActor
final class RecordingAnimator: SlideAnimating {
    var plans: [SlideAnimationPlan] = []
    var cancelCount = 0
    private var completion: ((Bool) -> Void)?
    func play(image: NSImage, plan: SlideAnimationPlan, completion: @escaping (Bool) -> Void) -> Bool {
        plans.append(plan)
        self.completion = completion
        return true
    }
    func cancel() {
        cancelCount += 1
        completion?(false)
        completion = nil
    }
    func finish() {
        completion?(true)
        completion = nil
    }
}

private func testImage() -> CGImage {
    let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemTeal.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    return context.makeImage()!
}

@Suite("slide integration")
@MainActor
struct SlideIntegrationTests {
    @Test("dock plays one overlay and finishes by showing the strip")
    func dockUsesOverlay() async {
        let fixture = makeIdleFixture(layout: testLayout)
        let animator = RecordingAnimator()
        fixture.delegate.slideAnimator = animator
        fixture.delegate.fakeCapturer.captureImage = testImage()
        fixture.managed.dock()
        await drainTasks()
        #expect(animator.plans.count == 1)
        #expect(fixture.managed.phase == .docked)
        #expect(fixture.window.storedFrame?.origin.x == -699)
        animator.finish()
        #expect(fixture.delegate.strip.isVisible)
    }

    @Test("peek uses the cached image and moves the real window only on completion")
    func peekUsesOverlay() async {
        let fixture = makeIdleFixture(layout: testLayout)
        let animator = RecordingAnimator()
        fixture.delegate.slideAnimator = animator
        fixture.delegate.fakeCapturer.captureImage = testImage()
        fixture.managed.dock()
        await drainTasks()
        animator.finish()
        fixture.delegate.fakeCapturer.cachedImage = NSImage(cgImage: testImage(), size: .zero)
        fixture.managed.peek()
        #expect(animator.plans.count == 2)
        #expect(fixture.window.storedFrame?.origin.x != 300)
        animator.finish()
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 300, y: 580))
    }

    @Test("a newer transition cancels the old overlay without losing the final state")
    func cancellationIsSafe() async {
        let fixture = makeIdleFixture(layout: testLayout)
        let animator = RecordingAnimator()
        fixture.delegate.slideAnimator = animator
        fixture.delegate.fakeCapturer.captureImage = testImage()
        fixture.managed.dock()
        await drainTasks()
        fixture.delegate.fakeCapturer.cachedImage = NSImage(cgImage: testImage(), size: .zero)
        fixture.managed.peek()
        #expect(animator.cancelCount >= 1)
        #expect(animator.plans.count == 2)
        animator.finish()
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 300, y: 580))
    }

    @Test("missing capture uses the original direct-move path")
    func noImageFallback() async {
        let fixture = makeIdleFixture(layout: testLayout)
        let animator = RecordingAnimator()
        fixture.delegate.slideAnimator = animator
        fixture.managed.dock()
        await drainTasks()
        #expect(animator.plans.isEmpty)
        #expect(fixture.window.storedFrame?.origin.x == -699)
    }
}
