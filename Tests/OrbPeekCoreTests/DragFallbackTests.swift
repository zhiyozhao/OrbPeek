import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("R2-3 mouse-button drag fallback")
@MainActor
struct DragFallbackTests {
    @Test("pressed mouse button prevents settling re-anchor and release resolves drag")
    func dragDuringSettling() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.window.mouseDown = true
        fixture.window.storedFrame = CGRect(x: 500, y: 480, width: 700, height: 500)

        tick(fixture, settling: true)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 500, y: 480))
        #expect(fixture.delegate.removed.isEmpty)

        fixture.window.mouseDown = false
        tick(fixture, settling: true)
        #expect(!fixture.managed.gesture)
        #expect(fixture.delegate.removed.count == 1)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 500, y: 480))
    }

    @Test("lost global mouseUp cannot leave gesture stuck")
    func lostMouseUp() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.managed.gesture = true
        fixture.window.mouseDown = true
        fixture.window.storedFrame?.origin.x = 650
        tick(fixture)

        fixture.window.mouseDown = false
        tick(fixture)
        #expect(!fixture.managed.gesture)
        #expect(fixture.managed.perp == 650)
        #expect(fixture.delegate.removed.isEmpty)
    }
}
