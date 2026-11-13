import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("cross-screen drag with misaligned edges")
@MainActor
struct MisalignedScreenDragTests {
    @Test("source-edge distance controls transfer even when target bottom is 80px lower")
    func misalignedBottomEdges() async {
        let source = ScreenInfo(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 80, width: 1920, height: 1000)
        )
        let layout = ScreenLayout(screens: [source, testSecondary])
        let fixture = await makeDockedFixture(layout: layout)
        fixture.managed.peek()
        #expect(fixture.window.storedFrame?.origin.y == 500)

        fixture.window.storedFrame = CGRect(x: 2200, y: 500, width: 700, height: 500)
        fixture.managed.checkDragOut()

        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.managed.dockScreen(in: fixture.delegate.geometry) == testSecondary)
        #expect(fixture.managed.perp == 280)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 2200, y: 580))
    }
}
