import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("docked-edge resize is not drag-out")
@MainActor
struct ResizeGestureTests {
    @Test("shrinking from the bottom edge stays docked and snaps flush")
    func bottomEdgeResize() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.managed.beginGesture(at: CGPoint(x: 650, y: 1080))
        fixture.window.storedFrame?.size.height = 400
        fixture.managed.endGesture()

        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.managed.phase == .peeked)
        #expect(fixture.window.storedFrame == CGRect(x: 300, y: 680, width: 700, height: 400))
        #expect(fixture.managed.restoreFrame.size.height == 400)
    }

    @Test("top-edge resize may change origin without becoming a move")
    func topEdgeResize() async {
        let fixture = await makeDockedFixture(layout: testLayout, edge: .up)
        fixture.managed.peek()
        #expect(fixture.window.storedFrame?.origin.y == 25)
        fixture.managed.beginGesture(at: CGPoint(x: 650, y: 25))
        fixture.window.storedFrame = CGRect(x: 300, y: 125, width: 700, height: 400)
        fixture.managed.endGesture()

        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.managed.phase == .peeked)
        #expect(fixture.window.storedFrame == CGRect(x: 300, y: 25, width: 700, height: 400))
        #expect(fixture.managed.restoreFrame.size.height == 400)
    }
}
