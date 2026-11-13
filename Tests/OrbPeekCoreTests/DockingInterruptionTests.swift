import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("R2-4 docking interrupted by native drag")
@MainActor
struct DockingInterruptionTests {
    @Test("mouse down during capture aborts parking")
    func mouseDownDuringCapture() async {
        let fixture = makeIdleFixture(layout: testLayout)
        fixture.delegate.fakeCapturer.onCapture = {
            fixture.window.mouseDown = true
            fixture.window.storedFrame?.origin.x = 600
        }
        fixture.managed.dock()
        await drainTasks()

        #expect(fixture.delegate.removed.count == 1)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 600, y: 200))
        #expect(fixture.window.positionWrites.isEmpty)
    }

    @Test("external movement during capture aborts stale parking")
    func movementDuringCapture() async {
        let fixture = makeIdleFixture(layout: testLayout)
        fixture.delegate.fakeCapturer.onCapture = {
            fixture.window.storedFrame?.origin = CGPoint(x: 650, y: 240)
        }
        fixture.managed.dock()
        await drainTasks()

        #expect(fixture.delegate.removed.count == 1)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 650, y: 240))
        #expect(fixture.window.positionWrites.isEmpty)
    }
}
