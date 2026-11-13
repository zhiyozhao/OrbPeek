import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("R2-1 drag release semantics")
@MainActor
struct DragSemanticsTests {
    @Test("parallel drag keeps dock and next peek uses new position")
    func parallelDrag() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.window.storedFrame?.origin.x = 650
        fixture.managed.checkDragOut()

        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.managed.perp == 650)
        fixture.managed.dock()
        await drainTasks()
        fixture.managed.peek()
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 650, y: 580))
    }

    @Test("dragging 35px inward snaps flush immediately on mouseUp")
    func shortInwardDragSnapsImmediately() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.window.storedFrame = CGRect(x: 650, y: 545, width: 700, height: 500)
        fixture.managed.checkDragOut()

        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.managed.phase == .peeked)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 650, y: 580))
        #expect(fixture.managed.restoreFrame.origin.x == 650)
    }

    @Test("outward off-screen drag also returns to a normal peeked position")
    func outwardDragSnapsImmediately() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.window.storedFrame?.origin.y = 700
        fixture.managed.checkDragOut()

        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 300, y: 580))
    }

    @Test("drag along edge to another screen changes dock screen and keeps relative position")
    func dragToAdjacentScreen() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.window.storedFrame = CGRect(x: 2200, y: 580, width: 700, height: 500)
        fixture.managed.checkDragOut()

        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.managed.dockScreen(in: fixture.delegate.geometry) == testSecondary)
        #expect(fixture.managed.perp == 280)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 2200, y: 580))

        fixture.managed.redock(to: .down)
        await drainTasks()
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 3839, y: 580))
    }

    @Test("drag beyond threshold still cancels dock")
    func dragBeyondThresholdReleases() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.window.storedFrame?.origin.y = 539 // 41px inward
        fixture.managed.checkDragOut()
        #expect(fixture.delegate.removed.count == 1)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 300, y: 539))
    }
}
