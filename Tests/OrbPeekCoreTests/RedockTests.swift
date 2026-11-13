import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("R2-2 explicit re-dock preserves current parallel position")
@MainActor
struct RedockTests {
    @Test("same-axis hotkey re-dock keeps the dragged position")
    func sameAxisRedock() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.window.storedFrame?.origin.x = 650
        fixture.managed.checkDragOut()

        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.managed.restoreFrame.origin.x == 650)
        fixture.managed.redock(to: .down)
        await drainTasks()

        #expect(fixture.managed.perp == 650)
        let screen = fixture.managed.dockScreen(in: fixture.delegate.geometry)!
        let expected = fixture.delegate.geometry.hiddenPosition(
            for: .down, size: fixture.window.storedFrame!.size,
            perp: 650, screen: screen
        )
        #expect(fixture.window.storedFrame?.origin == expected)
    }

    @Test("changing slide axis still derives perpendicular coordinate from restore frame")
    func changedAxisRedock() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.window.storedFrame?.origin.x = 650
        fixture.managed.checkDragOut()
        fixture.managed.redock(to: .left)
        await drainTasks()

        #expect(fixture.managed.perp == fixture.managed.restoreFrame.minY -
                fixture.delegate.geometry.quartzVisibleFrame(of: testPrimary).minY)
    }
}
