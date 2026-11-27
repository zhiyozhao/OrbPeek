import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("composited preview timing")
@MainActor
struct PreviewTimingTests {
    @Test("unobscured background windows capture at dock; obscured restores use identity and wait for hover")
    func background() async {
        let f = makeIdleFixture(layout: testLayout)
        f.delegate.frontmost = false
        f.managed.dock(); await drainTasks()
        #expect(f.delegate.fakeCapturer.captureCount == 1)
        #expect(!f.delegate.strip.identity.isEmpty)
        let g = makeIdleFixture(layout: testLayout)
        g.delegate.frontmost = false; g.delegate.fakeCapturer.captureAllowed = false
        g.managed.dock(); await drainTasks()
        #expect(g.delegate.fakeCapturer.captureCount == 0)
        #expect(g.managed.phase == .docked)
        g.delegate.fakeCapturer.captureAllowed = true
        g.managed.peek(); await drainTasks()
        #expect(g.delegate.fakeCapturer.captureCount == 1)
    }

    @Test("visible peek retries with backoff; hidden windows never poll for screenshots")
    func retries() async {
        let f = await makeDockedFixture(layout: testLayout)
        f.managed.peek(); await drainTasks()
        let count = f.delegate.fakeCapturer.captureCount
        // Failures are nil in FakeCapturer. We explicitly advance the fake clock.
        f.clock.advance(0.9)
        let point = f.window.frame!.origin
        f.managed.evaluate(mouseQ: point, mouseVelocity: .zero, frontmost: true, blockedByPeeked: false,
            blockedBySmaller: false, settling: false, now: f.clock.now)
        await drainTasks()
        #expect(f.delegate.fakeCapturer.captureCount == count)
        f.clock.advance(0.2)
        f.managed.evaluate(mouseQ: point, mouseVelocity: .zero, frontmost: true, blockedByPeeked: false,
            blockedBySmaller: false, settling: false, now: f.clock.now)
        await drainTasks()
        #expect(f.delegate.fakeCapturer.captureCount == count + 1)
        f.managed.dock(); await drainTasks()
        let parked = f.delegate.fakeCapturer.captureCount
        f.clock.advance(1000)
        f.managed.evaluate(mouseQ: .zero, mouseVelocity: .zero, frontmost: true, blockedByPeeked: false,
            blockedBySmaller: false, settling: false, now: f.clock.now)
        await drainTasks()
        #expect(f.delegate.fakeCapturer.captureCount == parked)
    }

    @Test("a hung initial capture leaves a usable strip and hover or slam can cancel parking", arguments: [false, true])
    func interactiveDuringCapture(slam: Bool) async {
        let f = makeIdleFixture(layout: testLayout)
        f.delegate.fakeCapturer.suspendCapture = true
        f.managed.dock(); await drainTasks()
        #expect(f.delegate.strip.isVisible)
        let screen = f.managed.dockScreen(in: f.delegate.geometry)!
        let rect = f.delegate.geometry.sliverRect(edge: .down, size: f.window.frame!.size,
            perp: f.managed.perp, screen: screen, thickness: f.delegate.config.sliverPx)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        for delta in (slam ? [0.0] : [0.0, 0.2]) {
            f.clock.advance(delta)
            f.managed.evaluate(mouseQ: point, mouseVelocity: slam ? CGPoint(x: 0, y: 2000) : .zero, frontmost: true, blockedByPeeked: false,
                blockedBySmaller: false, settling: false, now: f.clock.now)
        }
        #expect(f.managed.phase == .peeked)
        f.delegate.fakeCapturer.suspendCapture = false
        f.delegate.fakeCapturer.pendingCapture?.resume(returning: nil)
        await drainTasks()
        #expect(f.managed.phase == .peeked)
    }

    @Test("hidden re-dock uses cache or identity and never flashes a window for a screenshot")
    func hiddenRedock() async {
        let f = await makeDockedFixture(layout: testLayout)
        let captures = f.delegate.fakeCapturer.captureCount
        let parked = f.window.frame
        f.managed.redock(to: .down); await drainTasks()
        #expect(f.delegate.fakeCapturer.captureCount == captures)
        #expect(f.window.frame == parked)
        #expect(!f.delegate.strip.identity.isEmpty)
    }

    @Test("suspension gate prevents visible background capture and retries after it lifts")
    func captureGate() async {
        let f = await makeDockedFixture(layout: testLayout)
        var allowed = false
        f.managed.automaticPreviewAllowed = { allowed }
        let count = f.delegate.fakeCapturer.captureCount
        f.managed.peek(); await drainTasks()
        #expect(f.delegate.fakeCapturer.captureCount == count)
        allowed = true
        tick(f); await drainTasks()
        #expect(f.delegate.fakeCapturer.captureCount == count + 1)
    }

    @Test("retry schedule is finite and success or a new user peek resets it")
    func schedule() {
        var retry = PreviewRetry()
        var now = FakeClock().now
        retry.begin(at: now)
        for delay in [1.0, 4.0, 15.0] {
            #expect(retry.due(at: now))
            retry.finished(success: false, at: now)
            #expect(!retry.due(at: now.addingTimeInterval(delay - 0.1)))
            now = now.addingTimeInterval(delay)
        }
        retry.finished(success: false, at: now)
        #expect(!retry.due(at: now.addingTimeInterval(10000)))
        retry.begin(at: now); retry.finished(success: true, at: now)
        #expect(!retry.due(at: now.addingTimeInterval(10000)))
    }
}
